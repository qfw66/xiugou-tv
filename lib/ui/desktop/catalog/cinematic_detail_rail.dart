part of 'vod_detail_dialog.dart';

typedef _DetailRailEntry = ({String title, String subtitle, String? image});

class _DetailRail extends StatefulWidget {
  const _DetailRail({
    required this.heading,
    required this.entries,
    required this.pictureSize,
    required this.placeholder,
    this.emptyText,
    this.onPick,
    this.titleLines = 1,
    this.onImageUnavailable,
  });

  final String heading;
  final String? emptyText;
  final List<_DetailRailEntry> entries;
  final Size pictureSize;
  final IconData placeholder;
  final ValueChanged<String>? onPick;
  final int titleLines;
  final ValueChanged<_DetailRailEntry>? onImageUnavailable;

  @override
  State<_DetailRail> createState() => _DetailRailState();
}

class _DetailRailState extends State<_DetailRail> {
  final _scroll = ScrollController();
  static const _lineHeight = 1.4;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _drag(DragUpdateDetails details) {
    final position = _scroll.position;
    final dx = details.delta.dx;
    final offset =
        position.pixels +
        (axisDirectionIsReversed(position.axisDirection) ? dx : -dx);
    _scroll.jumpTo(
      offset.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final n = widget.entries.length;
      final width = widget.pictureSize.width;
      final overflow = n * width + (n - 1) * AppSpacing.md - box.maxWidth;
      final scaler = MediaQuery.textScalerOf(context);
      final textHeight =
          (scaler.scale(AppType.title) * _lineHeight).ceil() *
              widget.titleLines +
          (scaler.scale(AppType.label) * _lineHeight).ceil();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.heading, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          if (n == 0 && widget.emptyText != null) Text(widget.emptyText!),
          if (n > 0)
            SizedBox(
              height:
                  widget.pictureSize.height +
                  AppSpacing.sm +
                  textHeight +
                  AppSpacing.xs,
              child: MouseRegion(
                cursor: overflow > 0
                    ? SystemMouseCursors.grab
                    : MouseCursor.defer,
                child: GestureDetector(
                  supportedDevices: const {PointerDeviceKind.mouse},
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: overflow > 0 ? _drag : null,
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(
                      context,
                    ).copyWith(scrollbars: false),
                    child: ListView.separated(
                      key: PageStorageKey(widget.heading),
                      controller: _scroll,
                      // 滚轮交给整页，横栏的位移只来自按住鼠标拖动。
                      physics: const NeverScrollableScrollPhysics(),
                      scrollDirection: Axis.horizontal,
                      itemCount: n,
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: AppSpacing.md),
                      itemBuilder: (_, i) => _card(widget.entries[i]),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _card(_DetailRailEntry entry) {
    final palette = context.palette;
    final placeholder = ColoredBox(
      color: palette.raised,
      child: Icon(widget.placeholder, color: palette.textDim),
    );
    final radius = BorderRadius.circular(AppRadii.sm);
    final content = SizedBox(
      width: widget.pictureSize.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: radius,
            child: SizedBox.fromSize(
              size: widget.pictureSize,
              child: entry.image == null
                  ? placeholder
                  : Image(
                      image: DoubanRepository.isDoubanPoster(entry.image!)
                          ? DoubanPosterImage(entry.image!)
                          : NetworkImage(entry.image!),
                      fit: BoxFit.cover,
                      excludeFromSemantics: true,
                      errorBuilder: (_, __, ___) => Stack(
                        fit: StackFit.expand,
                        children: [
                          placeholder,
                          if (widget.onImageUnavailable case final notify?)
                            _ArtworkExhausted(() => notify(entry)),
                        ],
                      ),
                    ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            entry.title,
            maxLines: widget.titleLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.textMain,
              fontSize: AppType.title,
              height: _lineHeight,
            ),
          ),
          if (entry.subtitle.isNotEmpty)
            Text(
              entry.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.textSub,
                fontSize: AppType.label,
                height: _lineHeight,
              ),
            ),
        ],
      ),
    );
    final pick = widget.onPick;
    if (pick == null) return content;
    return Semantics(
      button: true,
      child: Tooltip(
        message: '在站源中搜索《${entry.title}》',
        child: InkWell(
          borderRadius: radius,
          onTap: () => pick(entry.title),
          child: content,
        ),
      ),
    );
  }
}
