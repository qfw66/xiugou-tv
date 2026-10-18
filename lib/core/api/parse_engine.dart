import 'dart:convert';
import 'package:dio/dio.dart';
import '../config/models/vod_config.dart';
import '../player/models/player_state.dart';

/// 视频播放地址解析引擎 (处理第三方解析规则与直链提取)
class ParseEngine {
  final Dio _dio;

  ParseEngine({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 12),
              ),
            );

  /// 根据原始播放地址与平台旗标解析可直接播放的流媒体地址 (m3u8 / mp4)
  Future<MediaPlaySpec> parse(String rawUrl, {String? flag, List<Parse> parses = const [], bool requireResolved = false}) async {
    final trimmed = rawUrl.trim();

    // 1. 如果本身已是标准直链媒体文件，无需调用解析接口
    if (!requireResolved && _isDirectMediaUrl(trimmed)) {
      return MediaPlaySpec(url: trimmed);
    }

    // 2. 遍历配置中的有效解析规则进行直链嗅探/接口解析
    for (final parseItem in parses) {
      try {
        if (parseItem.type == 1) {
          // JSON 接口解析
          final parseApi = parseItem.url;
          final targetUrl = '$parseApi$trimmed';

          final headers = <String, dynamic>{
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 xiugou-tv/5.6.3',
          };
          if (parseItem.header != null) {
            headers.addAll(parseItem.header!);
          }

          final response = await _dio.get(
            targetUrl,
            options: Options(headers: headers, responseType: ResponseType.plain),
          );

          final result = _extractUrlFromJson(response.data);
          if (result != null && result.isNotEmpty) {
            return MediaPlaySpec(
              url: result,
              headers: parseItem.header,
            );
          }
        }
      } catch (_) {
        // 单个解析接口失败时轮询下一个备用解析
        continue;
      }
    }

    if (requireResolved) {
      throw const FormatException('没有可用的 JSON 解析结果，暂不支持网页嗅探');
    }

    // 3. 所有解析器失效或无解析配置时，尝试直连播放
    return MediaPlaySpec(url: trimmed);
  }

  bool _isDirectMediaUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') ||
        lower.contains('.mp4') ||
        lower.contains('.flv') ||
        lower.contains('.ts') ||
        lower.contains('.mkv') ||
        lower.startsWith('rtmp://') ||
        lower.startsWith('rtsp://');
  }

  String? _extractUrlFromJson(dynamic raw) {
    if (raw == null) return null;
    try {
      final map = raw is Map ? raw : jsonDecode(raw.toString());
      if (map is Map) {
        final url = map['url']?.toString();
        if (url != null && url.isNotEmpty) return url;
        final data = map['data'];
        if (data is Map) {
          final dataUrl = data['url']?.toString();
          if (dataUrl != null && dataUrl.isNotEmpty) return dataUrl;
        }
      }
    } catch (_) {}
    return null;
  }
}
