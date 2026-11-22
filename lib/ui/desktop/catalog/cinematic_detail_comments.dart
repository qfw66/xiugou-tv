part of 'vod_detail_dialog.dart';

class _DetailComments extends StatefulWidget {
  const _DetailComments({super.key, required this.load});
  final Future<List<DoubanComment>> Function(CancelToken) load;

  @override
  State<_DetailComments> createState() => _DetailCommentsState();
}

class _DetailCommentsState extends State<_DetailComments> {
  final _cancel = CancelToken();
  late Future<List<DoubanComment>> _comments = widget.load(_cancel);

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final secondary = TextStyle(
      color: palette.textSub,
      fontSize: AppType.label,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('影片评论', style: Theme.of(context).textTheme.titleLarge),
            _CommentBadge('豆瓣 · 热门短评', color: palette.success),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        FutureBuilder<List<DoubanComment>>(
          future: _comments,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return Text('正在加载豆瓣短评…', style: secondary);
            }
            if (snapshot.hasError) {
              return Wrap(
                spacing: AppSpacing.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('豆瓣短评暂时不可用', style: secondary),
                  IconButton(
                    tooltip: '重试豆瓣短评',
                    icon: const Icon(Icons.refresh_rounded),
                    onPressed: () {
                      final next = widget.load(_cancel);
                      setState(() {
                        _comments = next;
                      });
                    },
                  ),
                ],
              );
            }
            final rows = snapshot.data ?? const [];
            if (rows.isEmpty) return Text('暂无可显示的豆瓣短评', style: secondary);
            return ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i != 0)
                      Divider(height: AppSpacing.xl, color: palette.border),
                    Wrap(
                      spacing: AppSpacing.md,
                      runSpacing: AppSpacing.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          rows[i].author.isEmpty ? '豆瓣用户' : rows[i].author,
                          style: TextStyle(
                            color: palette.textTitle,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (rows[i].stars case final stars?)
                          Semantics(
                            container: true,
                            label: '评分 $stars 星，满分 5 星',
                            excludeSemantics: true,
                            child: _CommentBadge(
                              '$stars / 5 星',
                              color: palette.warning,
                              icon: Icons.star_rounded,
                            ),
                          ),
                        if (rows[i].votes case final votes?)
                          Text('$votes 人觉得有用', style: secondary),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      rows[i].text,
                      style: TextStyle(
                        color: palette.textBody,
                        fontSize: AppType.lead,
                        height: 1.5,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _CommentBadge extends StatelessWidget {
  const _CommentBadge(this.label, {required this.color, this.icon});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ink = Color.lerp(color, palette.textTitle, .25)!;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: StadiumBorder(
          side: BorderSide(color: color.withValues(alpha: .35)),
        ),
        color: Color.alphaBlend(color.withValues(alpha: .20), palette.panel),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.xs,
          children: [
            if (icon != null) Icon(icon, size: AppType.title, color: ink),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: ink,
                  fontSize: AppType.label,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
