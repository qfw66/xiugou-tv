import 'danmaku_models.dart';

/// 弹幕候选的客户端校验与重排。
///
/// 服务端 `/danmaku` 按模糊相似度排序，片名只要「包含」相同的字就可能排第一：
/// 实测「繁花」首位是《星绽繁花》、「长安」首位是《长安的荔枝》、「他是谁」首位是《猜猜他是谁》；
/// 集名它认不出时（如「[05]」「HD国语」）会把**第 1 集**排第一（2026-10-31 实测《三体》）。
/// 无条件取首位就会把别的作品 / 别的集的弹幕放进当前影片。这里的原则是**宁缺毋错**：
///
/// 1. 只接受规范化后片名与当前影片**完全相同**的候选（不同作品一律排除）；
/// 2. 片名 / 集名里写了季数：只接受同一季（第一季也接受无季数的候选）；片名写了年份：排除年份不同的（重拍版）；
/// 3. 认出了集号：只接受集号相同的候选（电影候选只配第 1 集）；
///    多集剧认不出集号：一个都不用（不知道是哪一集，宁可不显示）；
///    单集片 / 电影：不接受明确标为剧集类的候选，也不接受第 2 集以后的候选；
/// 4. 其余按「季数更可能 → 年份一致 → 类型一致」排序，条件相同时保持服务端原顺序。
///
/// 一个都不剩时返回空列表，由调用方显示「未找到匹配弹幕」。
class DanmakuMatcher {
  const DanmakuMatcher._();

  static List<DanmakuCandidate> rank(
          String name, String episode, List<DanmakuCandidate> candidates,
          {int? episodeCount, String? yearHint}) =>
      select(
          DanmakuQuery(name: name, episode: episode, episodeCount: episodeCount, yearHint: yearHint),
          candidates);

  static List<DanmakuCandidate> select(DanmakuQuery query, List<DanmakuCandidate> candidates) {
    final title = query.title;
    if (title.base.isEmpty || query.episodeUnresolved) return const [];
    final season = query.season;
    final number = query.episodeNumber;
    final kind = query.kind;
    final preferYear = title.year ?? query.yearHintValue;
    final scored = <(DanmakuCandidate, List<int>)>[];
    for (var i = 0; i < candidates.length; i++) {
      final c = candidates[i];
      final info = TitleInfo.parseCandidate(c.name);
      if (info.base != title.base) continue;
      if (season != null && info.season != season && !(season == 1 && info.season == null)) {
        continue;
      }
      if (title.year != null && info.year != null && info.year != title.year) continue;
      final candidateEpisode = candidateEpisodeNumber(c.name);
      if (number != null) {
        if (candidateEpisode == null) {
          // 候选没写集号：只有电影能当作「第 1 集」
          if (!(number == 1 && info.kind == MediaKind.movie)) continue;
        } else if (candidateEpisode != number) {
          continue;
        }
      } else if (kind == MediaKind.movie) {
        if (info.kind == MediaKind.series) continue;
        if (candidateEpisode != null && candidateEpisode > 1) continue;
      }
      final seasonRank = season != null || info.season == null || info.season == 1 ? 0 : 1;
      final yearRank = preferYear == null || info.year == preferYear ? 0 : 1;
      final kindRank = kind == MediaKind.unknown || info.kind == MediaKind.unknown
          ? 1
          : (kind == info.kind ? 0 : 2);
      scored.add((c, [seasonRank, yearRank, kindRank, i]));
    }
    scored.sort((a, b) {
      for (var k = 0; k < a.$2.length; k++) {
        final d = a.$2[k].compareTo(b.$2[k]);
        if (d != 0) return d;
      }
      return 0;
    });
    return [for (final s in scored) s.$1];
  }

  /// 集名形态：「第 3 集」「03」「S01E03」「[1.76 GB]01-4K.mkv」→ 剧集；「正片」「HD」「1080P」→ 电影。
  ///
  /// 剧集判断在前：网盘文件名常同时带集号和画质词（`01-4K`），集号说明它是剧。
  static MediaKind episodeKind(String episode) {
    if (episode.trim().isEmpty) return MediaKind.unknown;
    if (EpisodeNumber.parse(episode).number != null) return MediaKind.series;
    final e = episode.toLowerCase();
    if (RegExp(r'正片|电影|hd|bd|tc|4k|1080|720|2160|蓝光|full').hasMatch(e)) {
      return MediaKind.movie;
    }
    return MediaKind.unknown;
  }

  /// 候选名里的集号：取片名之后第一个「第 N 集 / 话 / 期」（「第二季」的「季」不算）。
  ///
  /// 「庆余年 第二季(2024)【国产剧】from tencent - 【qq】 庆余年第二季 第3集 …」→ 3；
  /// 「流浪地球2(2023)【华语电影】from tencent - 【qq】 流浪地球2」→ null。
  static int? candidateEpisodeNumber(String name) {
    final m = RegExp(r'第\s*([0-9零〇一二两三四五六七八九十百]+)\s*[集话話期回]').firstMatch(name);
    return m == null ? null : parseChineseNumber(m.group(1)!);
  }
}

enum MediaKind { movie, series, unknown }

/// 一次弹幕匹配的输入：片名、集名与播放会话里能拿到的辅助信息。
class DanmakuQuery {
  DanmakuQuery({
    required this.name,
    required this.episode,
    this.episodeIndex,
    this.episodeCount,
    this.yearHint,
  })  : title = TitleInfo.parseQuery(name),
        parsedEpisode = EpisodeNumber.parse(episode, title: name);

  final String name;
  final String episode;

  /// 当前集在选集列表里的下标（0 起）；只用于认不出集号时区分请求，不拿来猜集号。
  final int? episodeIndex;

  /// 当前线路的总集数；1 = 单集片（电影 / 特别篇），null = 调用方不知道。
  final int? episodeCount;

  /// 站源给的年份（`vod_year`）：不可靠，只参与排序、不做排除。
  final String? yearHint;

  final TitleInfo title;
  final EpisodeNumber parsedEpisode;

  int? get episodeNumber => parsedEpisode.number;

  /// 片名的季数优先；片名没写时用集名里的 `S02E03`。
  int? get season => title.season ?? parsedEpisode.season;

  int? get yearHintValue {
    final m = RegExp(r'(19|20)\d{2}').firstMatch(yearHint ?? '');
    return m == null ? null : int.parse(m.group(0)!);
  }

  /// 本集形态：单集线路 / 「正片」「HD」= 电影（优先）；认出集号 = 剧集。
  MediaKind get kind {
    if (episodeCount == 1) return MediaKind.movie;
    if (episodeNumber != null) return MediaKind.series;
    final byName = DanmakuMatcher.episodeKind(episode);
    return byName == MediaKind.series ? MediaKind.unknown : byName;
  }

  /// 多集线路却认不出集号：无法确定是哪一集，不匹配。
  bool get episodeUnresolved => episodeNumber == null && (episodeCount ?? 0) > 1;

  /// 发给服务端的片名：去掉 `[4K]`「国语」等修饰（保留季数文字），减少服务端模糊匹配的干扰。
  String get searchName {
    final cleaned = TitleInfo.stripDecorations(name);
    return cleaned.isEmpty ? name.trim() : cleaned;
  }

  /// 发给服务端的集名：认出集号时统一成「第 N 集」（服务端认不出「[05]」这类写法，会退回第 1 集）。
  String get searchEpisode => episodeNumber == null ? episode.trim() : '第$episodeNumber集';

  /// 播放会话内的请求标识：规范化片名 + 季 + 集号（认不出集号时用集名 + 下标）。
  String get identity {
    final ep = episodeNumber != null ? 'e$episodeNumber' : 'x${episodeIndex ?? ''}:${episode.trim()}';
    return '${title.base}|s${season ?? ''}|y${title.year ?? ''}|$ep';
  }
}

/// 从集名里提取的集号与季号。
///
/// 支持「第3集 / 第三集 / 第05话」「S01E03」「EP03 / E03」「[05]」「03」「03.mp4」
/// 以及网盘文件名「[1.76 GB]01-4K.高码率.mkv」「醉梦.2026.E03.1080p.mkv」；
/// 文件大小、分辨率、年份、编码、码率等数字先剔除，避免误当集号。
class EpisodeNumber {
  const EpisodeNumber(this.number, {this.season});

  final int? number;
  final int? season;

  static const none = EpisodeNumber(null);

  /// [title] 为片名：集名里重复的片名先去掉，「流浪地球2.mp4」里的 2 不是集号。
  static EpisodeNumber parse(String episode, {String? title}) {
    var e = _halfWidth(episode).toLowerCase().trim();
    if (e.isEmpty) return none;

    final cn = RegExp(r'第\s*([0-9零〇一二两三四五六七八九十百]+)\s*[集话話期回]').firstMatch(e);
    if (cn != null) {
      final n = parseChineseNumber(cn.group(1)!);
      if (n != null) return EpisodeNumber(n);
    }
    final se = RegExp(r's(\d{1,2})\s*[._-]?\s*e(\d{1,4})(?!\d)').firstMatch(e);
    if (se != null) {
      return EpisodeNumber(int.parse(se.group(2)!), season: int.parse(se.group(1)!));
    }
    final ep = RegExp(r'(?:^|[^a-z0-9])(?:episode|ep|e)\s*(\d{1,4})(?!\d)').firstMatch(e);
    if (ep != null) return EpisodeNumber(int.parse(ep.group(1)!));
    if (RegExp(r'^\d{1,4}$').hasMatch(e)) return EpisodeNumber(int.parse(e));

    final base = title == null ? '' : TitleInfo.stripDecorations(_halfWidth(title)).toLowerCase();
    if (base.isNotEmpty) e = e.replaceAll(base, ' ');
    e = e
        .replaceAll(RegExp(r'\.(mp4|mkv|avi|ts|flv|rmvb|rm|m4v|mov|wmv|webm|iso|m2ts)$'), ' ')
        .replaceAll(RegExp(r'\d+(\.\d+)?\s*(gb|mb|g|m|kbps|mbps|fps|bit)\b'), ' ')
        .replaceAll(RegExp(r'\d{3,4}\s*[pi]\b|\b[2-8]k\b|[xh]\.?26[45]|\b(19|20)\d{2}\b'), ' ')
        .replaceAll(RegExp(r'\b(dts|ddp?|aac|ac3|atmos|truehd)\s*\d*(\.\d)?\b'), ' ');
    final bracket = RegExp(r'[\[【(（]\s*(\d{1,4})\s*[\]】)）]').firstMatch(e);
    if (bracket != null) return EpisodeNumber(int.parse(bracket.group(1)!));
    // 独立的 1~4 位数字：前后都不能紧挨数字、字母或小数点（排除「1.76」残留与「a3f9e1c2」这类哈希）
    final loose = RegExp(r'(?<![\da-z.])(\d{1,4})(?![\da-z]|\.\d)').firstMatch(e);
    if (loose != null) return EpisodeNumber(int.parse(loose.group(1)!));
    return none;
  }
}

/// 「12」「十二」「一百零五」「两」→ 整数；认不出返回 null。
int? parseChineseNumber(String raw) {
  final n = int.tryParse(raw);
  if (n != null) return n;
  const digits = {'零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9};
  var total = 0;
  var current = 0;
  var seen = false;
  for (final ch in raw.split('')) {
    if (digits.containsKey(ch)) {
      current = digits[ch]!;
      seen = true;
    } else if (ch == '十') {
      total += (seen && current == 0 ? 0 : (current == 0 ? 1 : current)) * 10;
      current = 0;
      seen = false;
    } else if (ch == '百') {
      total += (current == 0 ? 1 : current) * 100;
      current = 0;
      seen = false;
    } else {
      return null;
    }
  }
  final value = total + current;
  return value == 0 ? null : value;
}

String _halfWidth(String s) {
  final buf = StringBuffer();
  for (final rune in s.runes) {
    var r = rune;
    if (r >= 0xFF01 && r <= 0xFF5E) r -= 0xFEE0; // 全角 ASCII
    if (r == 0x3000) r = 0x20; // 全角空格
    buf.writeCharCode(r);
  }
  return buf.toString();
}

/// 片名拆解结果：规范化基名 + 季数 + 年份 + 类型。
class TitleInfo {
  const TitleInfo(this.base, {this.season, this.year, this.kind = MediaKind.unknown});

  /// 规范化后的片名（去季数、去标点空白、全角转半角、小写），只用于相等比较。
  final String base;
  final int? season;
  final int? year;
  final MediaKind kind;

  static final RegExp _bracket = RegExp(r'[\[【(（][^\]】)）]*[\]】)）]');

  /// 当前影片的片名：站源常带 `[4K]`、`(2023)`、`国语`、`2019` 之类的修饰，先剥掉再比较。
  static TitleInfo parseQuery(String name) {
    var text = name.trim();
    int? year;
    // 括号段：年份取出来，其余（[4K]、【国语】、(完结) …）整段丢弃
    text = text.replaceAllMapped(_bracket, (m) {
      final y = RegExp(r'^[\[【(（]\s*((19|20)\d{2})\s*[\]】)）]$').firstMatch(m.group(0)!);
      if (y != null) year ??= int.parse(y.group(1)!);
      return ' ';
    });
    final tokens = text.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    // 末尾独立的四位年份（「庆余年 2019」）；只有一个词时它就是片名本身（如《1917》）
    if (tokens.length > 1 && RegExp(r'^(19|20)\d{2}$').hasMatch(tokens.last)) {
      year ??= int.parse(tokens.removeLast());
    }
    final kept = tokens.where((t) => !_qualityTag.hasMatch(t)).join(' ');
    final (base, season) = _splitSeason(kept);
    return TitleInfo(_normalize(base), season: season, year: year);
  }

  /// 去掉括号段与画质 / 语言 / 完结等修饰词，保留片名与季数原文（发给服务端用）。
  static String stripDecorations(String name) {
    final tokens = name
        .replaceAll(_bracket, ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty && !_qualityTag.hasMatch(t))
        .toList();
    if (tokens.length > 1 && RegExp(r'^(19|20)\d{2}$').hasMatch(tokens.last)) tokens.removeLast();
    return tokens.join(' ');
  }

  /// 候选名形如「庆余年 第二季(2024)【国产剧】from tencent - 【qq】 …」或「醉梦(2026) - 第1集」。
  static TitleInfo parseCandidate(String name) {
    final cut = RegExp(r'[(（【]| from | - ').firstMatch(name);
    final title = cut == null ? name : name.substring(0, cut.start);
    final yearMatch = RegExp(r'[(（]\s*((19|20)\d{2})\s*[)）]').firstMatch(name);
    final category = RegExp(r'【([^】]*)】').firstMatch(name)?.group(1) ?? '';
    final kind = category.contains('电影')
        ? MediaKind.movie
        : RegExp(r'剧|动漫|番|综艺|纪录').hasMatch(category)
            ? MediaKind.series
            : MediaKind.unknown;
    final (base, season) = _splitSeason(title);
    return TitleInfo(_normalize(base),
        season: season,
        year: yearMatch == null ? null : int.parse(yearMatch.group(1)!),
        kind: kind);
  }

  /// 站源片名里常见、但不属于片名本身的独立修饰词（按空白切分后整词匹配，不会误伤片名内部）。
  static final RegExp _qualityTag = RegExp(
      r'^(4k|8k|hd|bd|tc|ts|hdr|uhd|1080p?|720p?|2160p?|蓝光|高清|超清|标清|国语|粤语|国粤|中字|中英字幕|双语|未删减|完整版|完结|全集|更新至.*)$',
      caseSensitive: false);

  /// 拆出季数：「第二季」「第2季」「S02」「Season 2」；裸数字（「流浪地球2」）属于片名，不当季数。
  static (String, int?) _splitSeason(String title) {
    final patterns = <RegExp>[
      RegExp(r'第\s*([0-9一二三四五六七八九十]+)\s*[季部]'),
      RegExp(r'\bseason\s*(\d{1,2})\b', caseSensitive: false),
      RegExp(r'\bs(\d{1,2})\b', caseSensitive: false),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(title);
      if (m == null) continue;
      final season = parseChineseNumber(m.group(1)!);
      if (season == null) continue;
      return (title.replaceRange(m.start, m.end, ' '), season);
    }
    return (title, null);
  }

  /// 全角转半角、小写、去掉一切非字母数字（含空白与中英文标点），只保留可比较的骨架。
  static String _normalize(String s) => _halfWidth(s)
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
}
