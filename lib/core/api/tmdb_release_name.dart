import 'models/vod_models.dart';

typedef TmdbReleaseName = ({String title, String year});

// 只识别独立的视频文件标签；前缀可带大小、站源年份和中文地区，后缀不参与搜索。
final _release = RegExp(
  r'^(?:[\[【]\s*\d+(?:\.\d+)?\s*[kmgt]i?b\s*[\]】]\s*)?'
  r'(?:[（(](?:18|19|20)\d{2}[）)]\s*)?(?:[\u3400-\u9fff]{1,12}\s+)?'
  r"([a-z0-9][a-z0-9 ._'’&-]{0,95}?)[ ._(（-]+((?:18|19|20)\d{2})[)）]?"
  r'(?:[ ._-]+(?:\d{3,4}[pi]|[48]k|bluray|blu-ray|web[ .-]?(?:dl|rip)|hdr|remux|中字|双语)[\w .中英简繁字幕双语-]*)?'
  r'\.(?:mp4|mkv|mov|m4v|avi|webm|ts|m2ts)$',
  caseSensitive: false,
);
final _notAFeature = RegExp(
  r'[/\\:?#=%@$|\x00-\x1f]|(?:^|[^a-z0-9])(?:www\.|(?:cookie|token|password|bearer|trailer|sample)(?![a-z0-9]))|预告|花絮',
  caseSensitive: false,
);
final _episodeMarker = RegExp(
  r'第[零一二三四五六七八九十百\d]+[季集]|(?:^|[^a-z0-9])(?:s\d{1,2}(?:e\d+)?|e\d{1,3}|season[ ._-]*\d+)(?![a-z0-9])',
  caseSensitive: false,
);

TmdbReleaseName? singleMovieReleaseName(
  String cardTitle,
  List<PlayFrom> sources,
) {
  if (sources.isEmpty || _episodeMarker.hasMatch(cardTitle)) return null;
  TmdbReleaseName? release;
  for (final source in sources) {
    if (source.episodes.isEmpty) continue;
    if (source.episodes.length != 1) return null;
    // 不读 episode.url，也不从链接、目录或多集列表中截取片名。
    final label = source.episodes.single.name.trim();
    if (label.length > 240 ||
        _notAFeature.hasMatch(label) ||
        _episodeMarker.hasMatch(label)) {
      return null;
    }
    final parts = _release.firstMatch(label);
    if (parts == null) continue;
    final title = parts[1]!.replaceAll(RegExp(r'[._\s]+'), ' ').trim();
    if (title.length < 2 || !RegExp('[a-zA-Z]').hasMatch(title)) continue;
    final year = parts[2]!;
    if (release != null &&
        (release.year != year ||
            release.title.toLowerCase() != title.toLowerCase())) {
      return null;
    }
    release ??= (title: title, year: year);
  }
  return release;
}
