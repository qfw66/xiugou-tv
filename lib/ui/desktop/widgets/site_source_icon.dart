import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/net/site_icon_url.dart';
import '../../theme/app_palette.dart';
import '../catalog/poster_image.dart';

/// 只请求明确提供的图标地址和站源请求头，不读取浏览器或账户状态。
ImageProvider? siteIconImageProvider(
  String? iconUrl, {
  Map<String, String>? headers,
}) {
  final url = resolveSiteIconUrl(iconUrl);
  if (url == null) return null;
  final uri = Uri.parse(url);
  if (uri.scheme == 'data') return posterImageProvider(url);
  if (uri.scheme == 'file') {
    try {
      return FileImage(File.fromUri(uri));
    } on ArgumentError {
      return null;
    }
  }
  final imageHeaders = <String, String>{};
  for (final entry in (headers ?? const <String, String>{}).entries) {
    final key = entry.key.trim();
    if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(key) ||
        RegExp(r'[\r\n\x00]').hasMatch(entry.value)) {
      continue;
    }
    imageHeaders[key.toLowerCase() == 'ua' ? 'User-Agent' : key] = entry.value;
  }
  // 不使用海报的中转回落或豆瓣地址推断；站源图标仅有这一个明确地址。
  return imageHeaders.isEmpty
      ? NetworkImage(url)
      : SitePosterImage(PosterSource(url,
          headers: Map<String, String>.unmodifiable(imageHeaders)));
}

/// 标题栏站源图标沿用原通用图标的尺寸、颜色和位置，图片保持原色。
class SiteSourceIcon extends StatelessWidget {
  const SiteSourceIcon({
    super.key,
    this.iconUrl,
    this.headers,
    this.size = 14,
  });

  final String? iconUrl;
  final Map<String, String>? headers;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(Icons.source_rounded,
        size: size, color: AppPalette.of(context).accentInk);
    final provider = siteIconImageProvider(iconUrl, headers: headers);
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: provider == null
            ? fallback
            : Image(
                key: ValueKey(provider),
                image: provider,
                width: size,
                height: size,
                fit: BoxFit.contain,
                excludeFromSemantics: true,
                frameBuilder: (context, child, frame, synchronous) =>
                    synchronous || frame != null ? child : fallback,
                errorBuilder: (context, error, stackTrace) => fallback,
              ),
      ),
    );
  }
}
