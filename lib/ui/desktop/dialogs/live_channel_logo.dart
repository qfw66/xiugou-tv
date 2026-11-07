import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/config/models/vod_config.dart';
import '../../theme/app_palette.dart';

/// 频道台标：本地文件 / http(s) 图片；地址为空、非法或加载失败时显示占位图标。
///
/// 「直播」管理弹窗的频道卡（标签布局）与频道行（两栏布局）共用。
class LiveChannelLogo extends StatelessWidget {
  final Live channel;
  final double size;
  final double fallbackSize;

  const LiveChannelLogo({
    super.key,
    required this.channel,
    this.size = 42,
    this.fallbackSize = 24,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final fallback = Icon(Icons.live_tv_rounded,
        color: palette.textSub, size: fallbackSize);
    final logo = channel.logoUrl;
    if (logo == null || logo.isEmpty) return fallback;
    final uri = Uri.tryParse(logo);
    if (uri?.scheme == 'file') {
      try {
        return Image.file(File.fromUri(uri!),
            width: size,
            height: size,
            fit: BoxFit.contain,
            cacheWidth: 96,
            errorBuilder: (_, __, ___) => fallback);
      } on UnsupportedError {
        return fallback;
      } on ArgumentError {
        return fallback;
      }
    }
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) {
      return fallback;
    }
    return Image.network(logo,
        width: size,
        height: size,
        fit: BoxFit.contain,
        cacheWidth: 96,
        errorBuilder: (_, __, ___) => fallback);
  }
}
