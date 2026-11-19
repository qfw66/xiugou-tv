import 'package:flutter/material.dart';

import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

class SourceHistoryTable extends StatefulWidget {
  const SourceHistoryTable({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<SourceHistoryTable> createState() => _SourceHistoryTableState();
}

class _SourceHistoryTableState extends State<SourceHistoryTable> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final height =
        (MediaQuery.sizeOf(context).height * .55).clamp(260.0, 560.0);
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Expanded(
                  child: Text('配置源 / 备注',
                      style: TextStyle(
                          fontSize: AppType.body, color: palette.textSub))),
              Text('操作',
                  style: TextStyle(
                      fontSize: AppType.body, color: palette.textSub)),
            ]),
          ),
          Divider(height: 1, color: palette.divider),
          Expanded(
            child: Scrollbar(
              controller: _scroll,
              thumbVisibility: true,
              child: ListView.separated(
                key: const ValueKey('config-source-table-scroll'),
                controller: _scroll,
                primary: false,
                padding: const EdgeInsets.only(right: 10),
                itemCount: widget.itemCount,
                itemBuilder: widget.itemBuilder,
                separatorBuilder: (_, __) =>
                    Divider(height: 1, color: palette.divider),
              ),
            ),
          ),
          Divider(height: 1, color: palette.divider),
        ],
      ),
    );
  }
}
