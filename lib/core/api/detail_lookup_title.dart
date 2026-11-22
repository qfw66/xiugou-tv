const _openingBracket = {')': '(', '）': '（', ']': '[', '】': '【'};
final _bracketYear = RegExp(r'^(?:18|19|20)\d{2}$');
final _quality = RegExp(
  r'至臻版?|超高清版?|高清版?|蓝光版?|杜比视界|杜比全景声|'
  r'4k|8k|2160p|1080[pi]|720p|uhd|hdr(?:10\+?)?|dolby[ -]?vision|blu-?ray|remux|web-dl',
  caseSensitive: false,
);
final _separator = RegExp(r'[ ·、+._-]+');

bool _isQualityLabel(String label) {
  var offset = 0;
  while (offset < label.length) {
    final token = _quality.matchAsPrefix(label, offset);
    if (token == null) return false;
    if (token.end == label.length) return true;
    offset = _separator.matchAsPrefix(label, token.end)?.end ?? token.end;
  }
  return false;
}

/// 只解析片尾完整的画质或年份标签；季数、副标题、剪辑版本仍是片名的一部分。
({String title, String year})? detailLookupTitle(
  String sourceTitle,
  String fieldYear,
) {
  var title = sourceTitle.trim();
  if (title.isEmpty || title.length > 160) return null;
  var year = fieldYear;
  while (title.isNotEmpty) {
    final opening = _openingBracket[title[title.length - 1]];
    if (opening == null) break;
    final start = title.lastIndexOf(opening);
    if (start < 0) break;
    final label = title.substring(start + 1, title.length - 1).trim();
    if (_bracketYear.hasMatch(label)) {
      if (year.isNotEmpty && year != label) return null;
      year = label;
    } else if (!_isQualityLabel(label)) {
      break;
    }
    title = title.substring(0, start).trimRight();
  }
  return title.isEmpty ? null : (title: title, year: year);
}
