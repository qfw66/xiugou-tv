import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'netflix_title_search_bar.dart';

/// 顶栏搜索栏的桥接模型。
///
/// 搜索输入用的 controller / focusNode 由主视图（`DesktopMainView`）持有——
/// 它要据此驱动搜索、分类内容与空态；而输入框本身渲染在标题栏里。两边通过
/// [homeSearchBridgeProvider] 连接：主视图发布，标题栏消费。
class HomeSearchBridge {
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final bool isSearching;
  final bool searchBusy;
  final bool isAggregate;
  final ValueChanged<String>? onSearch;
  final VoidCallback? onClear;
  final VoidCallback? onRefresh;
  final bool refreshBusy;
  final bool visible;

  const HomeSearchBridge({
    this.searchController,
    this.searchFocusNode,
    this.isSearching = false,
    this.searchBusy = false,
    this.isAggregate = true,
    this.onSearch,
    this.onClear,
    this.onRefresh,
    this.refreshBusy = false,
    this.visible = false,
  });
}

final homeSearchBridgeProvider =
    StateProvider<HomeSearchBridge>((ref) => const HomeSearchBridge());

/// 标题栏右侧的搜索区：主视图就绪后渲染紧凑搜索框 + 执行按钮。
///
/// 单独抽成组件的原因：生产环境的标题栏与用例（只挂 `DesktopMainView` 的
/// 那批）必须共用同一份「什么时候显示搜索框、按什么状态显示」的判断。
/// 搜索框从主视图搬到标题栏时，只改 app.dart 会让用例里的输入框凭空消失。
class HomeSearchBarHost extends ConsumerWidget {
  const HomeSearchBarHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bridge = ref.watch(homeSearchBridgeProvider);
    if (!bridge.visible ||
        bridge.searchController == null ||
        bridge.searchFocusNode == null) {
      return const SizedBox.shrink();
    }
    return NetflixTitleSearchBar(
      controller: bridge.searchController!,
      focusNode: bridge.searchFocusNode!,
      onSearch: bridge.onSearch ?? (_) {},
      onClear: bridge.onClear ?? () {},
      isBusy: bridge.searchBusy,
      isAggregate: bridge.isAggregate,
    );
  }
}
