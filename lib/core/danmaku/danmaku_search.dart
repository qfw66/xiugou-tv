/// 播放页「搜索弹幕」的纯逻辑：默认关键词、候选拆解、排序 / 过滤、中文提示。
///
/// 这里只做字符串与列表处理（不碰网络、不碰控制器状态），方便单测；
/// 真正的请求与绑定在 DanmakuController 上（searchCandidates / bind）。
///
/// 服务端 `/danmaku` 返回的只有 `name` + `url` 两项（无弹幕条数），候选名形如
/// 「醉梦(2026)【国产剧】from tencent - 【qq】 醉梦 第5集 家中遇贼…」：片名 / 年份 /
/// 来源 / 平台 / 集号都在名字里，取数 id 在 `url` 的 `/comment/<id>` 里。
library;

import 'danmaku_api.dart';
import 'danmaku_matcher.dart';
import 'danmaku_models.dart';

/// 搜索框默认关键词：当前片名去掉 `[4K]`「国语」(2023) 之类修饰。
///
/// 与 DanmakuQuery.searchName 同口径（自动匹配发的也是这个词），
/// 片子还没元数据时回退原文。
String danmakuSearchKeyword(String name) {
  final cleaned = TitleInfo.stripDecorations(name).trim();
  return cleaned.isEmpty ? name.trim() : cleaned;
}

/// 弹窗副标题：「当前：醉梦 · 第 5 集」。片名未知时给出输入提示。
String danmakuSearchSubtitle(String name, {int? episodeNumber}) {
  final title = name.trim();
  if (title.isEmpty) return '输入片名搜索弹幕';
  return episodeNumber == null ? '当前：$title' : '当前：$title · 第 $episodeNumber 集';
}

/// 搜索 / 绑定失败的中文提示（[error] 来自 DanmakuApi，文案里不会带服务地址与令牌）。
String danmakuSearchErrorText(Object error) {
  final raw = error is DanmakuException ? error.message.trim() : '';
  if (raw.isEmpty) return '搜索弹幕失败：网络异常';
  return switch (raw) {
    '已取消' => '搜索已取消',
    '无弹幕' => '这一集暂无弹幕',
    '未配置弹幕服务' => '未配置弹幕服务，无法搜索',
    _ => '搜索弹幕失败：$raw',
  };
}

/// 绑定候选失败时的提示：控制器的 message 已是中文，只补默认文案。
String danmakuBindErrorText(String? message) {
  final reason = message?.trim() ?? '';
  if (reason.isEmpty) return '弹幕加载失败';
  return reason == '无弹幕' ? '这条候选没有弹幕' : reason;
}

/// 一条候选的展示信息（只解析名字 / 地址，不做匹配决策）。
class DanmakuSearchEntry {
  const DanmakuSearchEntry({
    required this.candidate,
    required this.title,
    required this.year,
    required this.episodeNumber,
    required this.source,
    required this.platform,
    required this.id,
    required this.matchesEpisode,
  });

  final DanmakuCandidate candidate;

  /// 片名原文（去掉年份 / 【类型】/ 来源尾巴），如「醉梦」
  final String title;

  /// 候选名里的年份（重拍版靠它区分）
  final int? year;

  /// 候选名里的集号（认不出为 null）
  final int? episodeNumber;

  /// `from` 后面的来源站（tencent / 360 / youku …）
  final String? source;

  /// 来源尾巴里的平台标记（`- 【qq】`）
  final String? platform;

  /// 取数地址里的分集 id（服务端内存缓存分配，重启会变，只能当提示）
  final String? id;

  /// 是否就是当前播放的这一集
  final bool matchesEpisode;

  /// 标题行：片名 + 年份
  String get label => year == null ? title : '$title ($year)';

  /// 集数标签（认不出集号时为空）
  String? get episodeLabel =>
      episodeNumber == null ? null : '第 $episodeNumber 集';

  /// 副标题：来源 · 平台 · 分集 id（缺的项不占位）
  String get detail => [
        if (source != null) source!,
        if (platform != null) platform!,
        if (id != null) '#$id',
      ].join(' · ');

  /// 列表一行展示的完整名字（tooltip 用，用户能核对原文）
  String get fullName => candidate.name;

  static final RegExp _year = RegExp(r'[(（]\s*((?:19|20)\d{2})\s*[)）]');
  static final RegExp _headCut = RegExp(r'[(（【]|\sfrom\s|\s-\s');
  static final RegExp _episodeMark =
      RegExp(r'第\s*[0-9零〇一二两三四五六七八九十百]+\s*[集话話期回]');
  static final RegExp _source = RegExp(r'\bfrom\s+([A-Za-z0-9_.-]+)');
  static final RegExp _platform = RegExp(r'-\s*【([^】]+)】');
  static final RegExp _commentId = RegExp(r'/comment/(\d+)');

  /// 拆一条候选；[episodeNumber] 为当前播放的集号（认不出时传 null）。
  static DanmakuSearchEntry parse(DanmakuCandidate candidate,
      {int? episodeNumber}) {
    final name = candidate.name.trim();
    // 片名截到第一个「修饰 / 集号」标记为止：'醉梦(2026) - 第1集' 与 '醉梦 第1集' 都只留「醉梦」
    var cut = _headCut.firstMatch(name)?.start ?? name.length;
    final mark = _episodeMark.firstMatch(name);
    if (mark != null && mark.start < cut) cut = mark.start;
    var title = name.substring(0, cut).trim();
    if (title.isEmpty) title = name;
    final year = int.tryParse(_year.firstMatch(name)?.group(1) ?? '');
    final candidateEpisode = DanmakuMatcher.candidateEpisodeNumber(name);
    return DanmakuSearchEntry(
      candidate: candidate,
      title: title,
      year: year,
      episodeNumber: candidateEpisode,
      source: _source.firstMatch(name)?.group(1),
      platform: _platform.firstMatch(name)?.group(1),
      id: _commentId.firstMatch(candidate.url)?.group(1),
      matchesEpisode:
          episodeNumber != null && candidateEpisode == episodeNumber,
    );
  }
}

/// 一次搜索的展示模型：候选列表 + 空结果该说什么。
class DanmakuSearchView {
  const DanmakuSearchView({
    required this.keyword,
    required this.episodeNumber,
    required this.total,
    required this.matchingCount,
    required this.entries,
    required this.onlyCurrentEpisode,
  });

  final String keyword;

  /// 当前播放的集号（认不出为 null → 没有「仅本集」过滤）
  final int? episodeNumber;

  /// 服务端返回的候选总数（过滤前）
  final int total;

  final int matchingCount;

  /// 要显示的候选（本集在前，其余随后，组内保持服务端顺序）
  final List<DanmakuSearchEntry> entries;

  /// 是否只看本集
  final bool onlyCurrentEpisode;

  bool get isEmpty => entries.isEmpty;

  /// 过滤后为空、但关掉「仅本集」还有候选：给一个「查看全部」的出路。
  bool get filterHidesAll =>
      onlyCurrentEpisode && episodeNumber != null && matchingCount == 0 && total > 0;

  /// 空列表 / 请求失败的中文说明。
  String get emptyMessage {
    if (total == 0) return '没有找到「$keyword」的弹幕，换个片名再试';
    if (filterHidesAll) {
      return '「$keyword」没有第 $episodeNumber 集的候选，可以关掉「仅本集」看全部';
    }
    return '没有可显示的候选';
  }

  /// 按 [onlyCurrentEpisode] 过滤并排序；[episodeNumber] 为 null 时不过滤。
  static DanmakuSearchView build({
    required String keyword,
    required List<DanmakuCandidate> candidates,
    int? episodeNumber,
    bool onlyCurrentEpisode = false,
  }) {
    final entries = [
      for (final c in candidates)
        DanmakuSearchEntry.parse(c, episodeNumber: episodeNumber),
    ];
    final matching = entries.where((e) => e.matchesEpisode).toList();
    final rest = entries.where((e) => !e.matchesEpisode).toList();
    final filter = onlyCurrentEpisode && episodeNumber != null;
    return DanmakuSearchView(
      keyword: keyword.trim(),
      episodeNumber: episodeNumber,
      total: candidates.length,
      matchingCount: matching.length,
      entries: filter ? matching : [...matching, ...rest],
      onlyCurrentEpisode: filter,
    );
  }
}
