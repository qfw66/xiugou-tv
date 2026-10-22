import 'package:flutter/material.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'focus_ring.dart';

/// Netflix 风格顶栏紧凑型搜索栏组件 (Netflix Title Search Bar)
///
/// 视觉特性：
/// 1. 紧凑尺寸：宽 240~260px，高 30px（缩小版，不再占据整行大通栏）；
/// 2. 微透磨砂质感底板，聚焦呈现 accentInk 柔光微光晕；
/// 3. 内置清空按钮与搜索快捷按钮（搜索中自动切换为精致小菊花）；
/// 4. 键盘 Enter 回车与鼠标点击双模触发。
class NetflixTitleSearchBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSearch;
  final VoidCallback onClear;
  final bool isBusy;
  final bool isAggregate;

  const NetflixTitleSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSearch,
    required this.onClear,
    this.isBusy = false,
    this.isAggregate = true,
  });

  @override
  State<NetflixTitleSearchBar> createState() => _NetflixTitleSearchBarState();
}

class _NetflixTitleSearchBarState extends State<NetflixTitleSearchBar> {
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final hasFocus = widget.focusNode.hasFocus;
    final hasText = widget.controller.text.isNotEmpty;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 紧凑型搜索输入胶囊
        AnimatedContainer(
          duration: hasFocus ? AppMotion.enter : AppMotion.exit,
          curve: AppMotion.ease,
          width: 240,
          height: 30,
          decoration: BoxDecoration(
            color: hasFocus
                ? palette.raised
                : (Theme.of(context).brightness == Brightness.dark
                    ? Colors.white.withValues(alpha: 0.08)
                    : palette.raised),
            borderRadius: BorderRadius.circular(AppRadii.pill),
            border: Border.all(
              color: hasFocus
                  ? palette.accentInk
                  : (_isHovered
                      ? palette.borderStrong
                      : context.glassBorder),
              width: hasFocus ? 1.4 : 0.8,
            ),
            boxShadow: hasFocus
                ? [
                    BoxShadow(
                      color: palette.accentInk.withValues(alpha: 0.22),
                      blurRadius: 8,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: MouseRegion(
            onEnter: (_) => setState(() => _isHovered = true),
            onExit: (_) => setState(() => _isHovered = false),
            child: Row(
              children: [
                const SizedBox(width: 8),
                Icon(
                  Icons.search_rounded,
                  size: 15,
                  color: hasFocus ? palette.accentInk : palette.textDim,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    // 中文在高 30 的胶囊里容易「看着偏下」：字体自带的
                    // leading 默认按比例分配（上小下大）。把行盒按字号固定，
                    // 并让上下 leading 均分，文字块才是视觉居中。
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: palette.textMain,
                      height: 1.2,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                    strutStyle: const StrutStyle(
                      fontSize: AppType.caption,
                      height: 1.2,
                      forceStrutHeight: true,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: widget.isAggregate
                          ? '搜索全网影片…'
                          : '搜索当前站源…',
                      hintStyle: TextStyle(
                        fontSize: AppType.caption,
                        color: palette.textDim,
                      ),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onSubmitted: widget.onSearch,
                  ),
                ),
                if (hasText)
                  FocusRing(
                    onTap: widget.onClear,
                    semanticLabel: '清空搜索',
                    borderRadius: BorderRadius.circular(AppRadii.pill),
                    child: GestureDetector(
                      onTap: widget.onClear,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(
                          Icons.close_rounded,
                          size: 14,
                          color: palette.textSub,
                        ),
                      ),
                    ),
                  )
                else
                  const SizedBox(width: 6),
              ],
            ),
          ),
        ),

        const SizedBox(width: 6),

        // 搜索执行按钮（微透圆形药丸）
        Tooltip(
          message: widget.isAggregate ? '全网聚合搜索' : '搜索当前站源',
          child: FocusRing(
            onTap: () => widget.onSearch(widget.controller.text),
            semanticLabel: '执行搜索',
            borderRadius: BorderRadius.circular(AppRadii.pill),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: widget.isBusy
                    ? null
                    : () => widget.onSearch(widget.controller.text),
                borderRadius: BorderRadius.circular(AppRadii.pill),
                hoverColor: palette.hover,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.05),
                    border: Border.all(
                      color: context.glassBorder,
                      width: 0.8,
                    ),
                  ),
                  child: Center(
                    child: widget.isBusy
                        ? SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.8,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  palette.accentInk),
                            ),
                          )
                        : Icon(
                            Icons.arrow_forward_rounded,
                            size: 15,
                            color: palette.accentInk,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
